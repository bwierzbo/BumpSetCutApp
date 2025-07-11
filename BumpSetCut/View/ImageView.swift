//
//  ImageView.swift
//  BasicAVCamera
//
//  Created by Itsuki on 2024/05/19.
//

import SwiftUI

struct ImageView: View {
    var image: Image?
    var body: some View {
        GeometryReader { geometry in
            if let image = image {
                image
                    .resizable()
                    .scaledToFill()     // preserve aspect ratio, fill the container
                    .clipped()          // cut off any overflow
                    .ignoresSafeArea()
            }
        }
    }
}
